import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

@MainActor
@Suite("Plugin manifests")
struct PluginManifestTests {
    @Test("Every plugin is official, by Keybumps, with a category, and declares each preference key once")
    func manifests() {
        for descriptor in CapabilityCatalog.descriptors {
            #expect(descriptor.publisher == .keybumps)
            let keys = descriptor.preferences.map(\.key)
            #expect(Set(keys).count == keys.count, "\(descriptor.capability) repeats a key")
        }
        #expect(CapabilityDescriptor.timer.category == .productivity)
        #expect(CapabilityDescriptor.dictation.category == .writing)
        #expect(PluginSettingsPage<EmptyView, EmptyView, EmptyView>.byline(.timer) == "Official plugin by Keybumps · Productivity")
        #expect(CapabilityOffBanner.title(.emojiPicker) == "Emoji Picker is turned off")
    }

    @Test("A plugin's shortcuts and preference groups come from its manifest, in order")
    func derived() {
        #expect(CapabilityDescriptor.timer.shortcuts == [.timer])
        #expect(CapabilityDescriptor.screenshotTools.shortcuts == [
            .screenshotScreen, .screenshotScreenAndEdit, .screenshotArea,
            .screencast, .screencastPause, .screencastStop, .screencastDiscard, .screencastDraw,
        ])
        #expect(CapabilityDescriptor.timer.preferenceGroups.map(\.title) == ["When a timer ends", "Menu bar"])
        #expect(CapabilityDescriptor.timer.preferenceGroups.map { $0.preferences.map(\.key) } == [
            ["ringsUntilStopped"], ["showsMenuBarCountdown", "listsTimersInMenu"],
        ])
    }

    @Test("A preference is its default until set, is stored under the plugin's name, and survives a relaunch")
    func storage() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.bool(.timerRings, for: .timer))

        preferences.set(.bool(false), of: .timerRings, for: .timer)
        #expect(!preferences.bool(.timerRings, for: .timer))
        #expect(defaults.object(forKey: "plugin.timer.ringsUntilStopped") as? Bool == false)
        #expect(!AppPreferences(defaults: defaults).bool(.timerRings, for: .timer))
    }

    @Test("A switch reads numbers and the strings defaults write and launch arguments give; anything else is the default")
    func storedSwitches() {
        let defaults = InMemoryDefaults()
        defaults.set("loud", forKey: "plugin.timer.ringsUntilStopped")
        #expect(AppPreferences(defaults: defaults).bool(.timerRings, for: .timer))
        defaults.set("NO", forKey: "plugin.timer.ringsUntilStopped")
        #expect(!AppPreferences(defaults: defaults).bool(.timerRings, for: .timer))
        #expect(PluginPreference.timerRings.value(fromStored: "0") == .bool(false))
        #expect(PluginPreference.timerRings.value(fromStored: "true") == .bool(true))
        #expect(PluginPreference.timerRings.value(fromStored: NSNumber(value: 0)) == .bool(false))
        #expect(PluginPreference.timerRings.value(fromStored: nil) == nil)
    }

    @Test("A menu keeps only one of its options, stored or set")
    func choices() {
        let choice = PluginPreference(
            key: "size", title: "Size", group: "Look",
            kind: .choice(options: [.init(value: "s", title: "Small"), .init(value: "l", title: "Large")], default: "s")
        )
        #expect(choice.defaultValue == .choice("s"))
        #expect(choice.storageKey(for: .timer) == "plugin.timer.size")
        #expect(choice.value(fromStored: "l") == .choice("l"))
        #expect(choice.value(fromStored: "x") == nil)
        #expect(choice.value(fromStored: 5) == nil)
        #expect(choice.accepts(.choice("l")))
        #expect(!choice.accepts(.choice("x")))
        #expect(!choice.accepts(.bool(true)))
    }

    @Test("Setting a value of the wrong kind, or a preference the plugin doesn't declare, changes nothing")
    func setRejects() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.set(.choice("loud"), of: .timerRings, for: .timer)
        #expect(preferences.bool(.timerRings, for: .timer))
        preferences.set(.bool(false), of: .timerRings, for: .snippets)
        #expect(defaults.object(forKey: "plugin.snippets.ringsUntilStopped") == nil)
    }

    @Test("Every declared menu's default is one of its options, its options are distinct, and no key collides with the page's own identifiers")
    func declarationsAreValid() {
        for descriptor in CapabilityCatalog.descriptors {
            for preference in descriptor.preferences {
                #expect(preference.accepts(preference.defaultValue), "\(descriptor.capability).\(preference.key)")
                if case .choice(let options, _) = preference.kind {
                    #expect(Set(options.map(\.value)).count == options.count)
                }
                #expect(preference.key != "byline")
                if let key = preference.differsFrom {
                    let counterpart = descriptor.preferences.first { $0.key == key }
                    #expect(counterpart?.differsFrom == preference.key, "\(descriptor.capability).\(preference.key) and \(key) differ from each other")
                    #expect(counterpart.map { $0.defaultValue != preference.defaultValue } == true, "Their defaults differ")
                }
            }
        }
    }

    @Test("A permission is required or optional, never both, and an optional one says why")
    func optionalPermissions() {
        for descriptor in CapabilityCatalog.descriptors {
            let optional = descriptor.optionalPermissions.map(\.permission)
            #expect(Set(optional).count == optional.count, "\(descriptor.title) lists an optional permission twice")
            #expect(descriptor.requiredPermissions.isDisjoint(with: optional), "\(descriptor.title)")
            let reasonsGiven = descriptor.optionalPermissions.allSatisfy { !$0.reason.isEmpty }
            #expect(reasonsGiven, "\(descriptor.title)")
        }
    }

    @Test("Every plugin whose tab pastes with ⌘P declares Accessibility, which pasting into another app needs (#370)")
    func pastingPluginsDeclareAccessibility() {
        let pasting = CapabilityCatalog.descriptors.filter { descriptor in
            descriptor.paletteTab?.secondaryActions.contains { $0.keys == PaletteKeyAction.paste().keys } == true
        }
        #expect(pasting.map(\.capability) == [.clipboardHistory, .screenshotTools, .dictation, .snippets, .emojiPicker, .translation])
        for descriptor in pasting {
            let declared = descriptor.requiredPermissions.union(descriptor.optionalPermissions.map(\.permission))
            #expect(declared.contains(.accessibility), "\(descriptor.title)")
        }
        #expect(CapabilityDescriptor.clipboardHistory.optionalPermissions.map(\.permission) == [.accessibility])
        #expect(CapabilityDescriptor.screenshotTools.optionalPermissions.map(\.permission) == [.accessibility, .microphone, .inputMonitoring])
        #expect(CapabilityDescriptor.dictation.requiredPermissions.contains(.accessibility), "Dictation needs it anyway")
    }

    @Test("A new install starts with every plugin on except those that ship off")
    func newInstallSkipsPluginsThatShipOff() {
        let started = AppPreferences.initialCapabilities(stored: nil, known: nil, shippingOff: [.timer])
        #expect(started == Set(Capability.allCases).subtracting([.timer]))
        #expect(AppPreferences.initialCapabilities(stored: nil, known: nil, shippingOff: []) == Set(Capability.allCases))
    }

    @Test("An update turns on a plugin it adds only if that plugin ships on, and keeps what was on")
    func updateTurnsOnOnlyPluginsThatShipOn() {
        let known = Capability.allCases.filter { $0 != .timer }.map(\.rawValue)
        let stored = ["quickSearch", "snippets"]
        #expect(AppPreferences.initialCapabilities(stored: stored, known: known, shippingOff: [.timer]) == [.quickSearch, .snippets])
        #expect(AppPreferences.initialCapabilities(stored: stored, known: known, shippingOff: []) == [.quickSearch, .snippets, .timer])
        // Once known, a plugin that ships off stays as the person left it.
        let allKnown = Capability.allCases.map(\.rawValue)
        #expect(AppPreferences.initialCapabilities(stored: stored + ["timer"], known: allKnown, shippingOff: [.timer]).contains(.timer))
    }

    @Test("An install from before plugins were tracked gets the ones that ship on, never one that ships off")
    func oldInstallSkipsPluginsThatShipOff() {
        // No known list: only the original five were known.
        let started = AppPreferences.initialCapabilities(stored: ["dictation"], known: nil, shippingOff: [.timer])
        let added = Set(Capability.allCases).subtracting(Capability.originalCapabilities).subtracting([.timer])
        #expect(started == added.union([.dictation]))
        #expect(!started.contains(.timer))
    }

    @Test("An optional permission that isn't granted reads Not Granted, never Required")
    func optionalPermissionStatus() {
        let missing = PermissionAuthorizationState.required
        #expect(PermissionRow.status(missing, requiresRelaunch: false, isOptional: true) == "Not Granted")
        #expect(PermissionRow.status(missing, requiresRelaunch: false, isOptional: false) == missing.rawValue)
        #expect(PermissionRow.status(missing, requiresRelaunch: true, isOptional: true) == "Restart Required")
    }

    @Test("Every plugin ships on except the Emoji Picker, the first that ships off (#243), Translation (#322), and Keystrokes (#443); Screengrabs, which took in Screencast (#445), ships on (#490)")
    func onlyTheEmojiPickerTranslationAndKeystrokesShipOff() {
        #expect(CapabilityCatalog.descriptors.filter { !$0.isOnByDefault }.map(\.capability) == [.emojiPicker, .translation, .keystrokes])
        #expect(CapabilityDescriptor.emojiPicker.optionalPermissions.map(\.permission) == [.accessibility])
        #expect(CapabilityDescriptor.translation.optionalPermissions.map(\.permission) == [.accessibility])
        #expect(CapabilityDescriptor.translation.requiredPermissions.isEmpty)
        #expect(CapabilityDescriptor.keystrokes.requiredPermissions == [.inputMonitoring], "Its keyboard tap needs it")
        #expect(CapabilityDescriptor.keystrokes.optionalPermissions.isEmpty)
    }

    @Test("Only Translation (#322) needs a newer macOS than Keybumps does; Screengrabs' recording needs it inside the plugin (#490)")
    func minimumMacOS() {
        #expect(CapabilityCatalog.descriptors.filter { $0.minimumMacOS != nil }.map(\.capability) == [.translation])
        #expect(CapabilityDescriptor.translation.minimumMacOS == 15)
        #expect(CapabilityDescriptor.screenshotTools.minimumMacOS == nil)
        #expect(!PluginCompatibility(macOSMajorVersion: 14).supportsRecording)
        #expect(PluginCompatibility(macOSMajorVersion: 15).supportsRecording)
    }

    @Test(
        "Every plugin's Settings page shows each optional permission it declares, marked Optional, and no permission it doesn't declare, once (#379)",
        arguments: [nil, MacPermission.accessibility]
    )
    func pagesShowTheirPermissions(missing: MacPermission?) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsPluginPermissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: Set(Capability.allCases), missing: missing, root: root)
        for descriptor in CapabilityCatalog.descriptors {
            let page = try #require(descriptor.settingsPage, "\(descriptor.title) has a Settings page")
            let shown = RowsOnPage.read(page.content(), model: harness.model).permissions
            let optional = descriptor.optionalPermissions.map { PermissionRow.Shown(permission: $0.permission, isOptional: true) }
            #expect(shown.filter(\.isOptional) == optional, "\(descriptor.title) shows \(shown)")
            let required = shown.filter { !$0.isOptional }.map(\.permission)
            #expect(Set(required).isSubset(of: descriptor.requiredPermissions), "\(descriptor.title) shows \(shown)")
            #expect(Set(shown).count == shown.count, "\(descriptor.title) shows a permission twice: \(shown)")
        }
    }

    @Test("Every plugin's Settings page draws each preference it declares once, those placed at the top first, under its header")
    func pagesDrawTheirPreferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsPluginPreferences-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root)
        for descriptor in CapabilityCatalog.descriptors {
            let page = try #require(descriptor.settingsPage, "\(descriptor.title) has a Settings page")
            let drawn = RowsOnPage.read(page.content(), model: harness.model).preferences
            let declared = descriptor.preferences.map(\.key)
            #expect(drawn.count == declared.count && Set(drawn) == Set(declared), "\(descriptor.title) draws \(drawn), each once")
            let top = descriptor.topPreferences.map(\.key)
            #expect(Array(drawn.prefix(top.count)) == top, "\(descriptor.title) draws \(drawn)")
            #expect(drawn == top + descriptor.preferenceGroups.flatMap { $0.preferences.map(\.key) }, "then by group")
        }
        #expect(CapabilityDescriptor.keystrokes.topPreferences.map(\.key) == ["showing"])
        #expect(!CapabilityDescriptor.keystrokes.preferenceGroups.contains { $0.preferences.contains(.keystrokesShowing) }, "Not in a group as well")
    }

    @Test("A preference placed at the top can't change while its plugin is off, since turning Keystrokes on shows its keys; the others can")
    func topPreferencesWaitForThePlugin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsTopPreferences-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [], missing: nil, root: root)
        for descriptor in CapabilityCatalog.descriptors {
            let page = try #require(descriptor.settingsPage)
            let rows = RowsOnPage.read(page.content(), model: harness.model)
            #expect(rows.disabled == descriptor.topPreferences.map(\.key), "\(descriptor.title) off draws \(rows.disabled) disabled")
        }
        #expect(RowsOnPage.read(try #require(CapabilityDescriptor.keystrokes.settingsPage).content(), model: harness.model).disabled == ["showing"])

        let on = WiringHarness(enabled: [.keystrokes], missing: nil, root: root)
        let rows = RowsOnPage.read(try #require(CapabilityDescriptor.keystrokes.settingsPage).content(), model: on.model)
        #expect(rows.preferences.first == "showing")
        #expect(rows.disabled.isEmpty, "Show keystrokes can change once Keystrokes is on")
    }
}

@MainActor
@Suite("Plugin Settings pages")
struct PluginSettingsPageTests {
    @Test("The slot above the declared preferences is drawn after those placed at the top and before the groups, and is empty unless a page fills it (#490)")
    func slotAboveThePreferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsPluginPageSlots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root).model
        let top = CapabilityDescriptor.keystrokes.topPreferences.map(\.key)
        let groups = CapabilityDescriptor.keystrokes.preferenceGroups.flatMap { $0.preferences.map(\.key) }
        try #require(!top.isEmpty && !groups.isEmpty, "Keystrokes has preferences at the top and in groups")

        let filled = PluginSettingsPage(capability: .keystrokes) { Marker(name: "above") } custom: { Marker(name: "custom") }
        #expect(RowsOnPage.read(AnyView(filled), model: model).preferences == top + ["above"] + groups + ["custom"])

        // The pages already on the template: Translation's fills only the last slot, and the
        // others but Screengrabs' neither.
        let last = PluginSettingsPage(capability: .keystrokes) { Marker(name: "custom") }
        #expect(RowsOnPage.read(AnyView(last), model: model).preferences == top + groups + ["custom"])
        #expect(RowsOnPage.read(AnyView(PluginSettingsPage(capability: .keystrokes)), model: model).preferences == top + groups)
    }

    @Test("The rows a page adds to one of its declared groups end that group, and a group that can't change draws its preferences disabled (#490)")
    func groupRowsAndUnavailableGroups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsPluginPageGroupRows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root).model
        let top = CapabilityDescriptor.keystrokes.topPreferences.map(\.key)
        let groups = CapabilityDescriptor.keystrokes.preferenceGroups
        let first = try #require(groups.first)

        let page = PluginSettingsPage(capability: .keystrokes, unavailableGroups: [first.title]) {
            EmptyView()
        } groupRows: { group in
            Marker(name: "end of \(group)")
        } custom: {
            Marker(name: "custom")
        }
        let rows = RowsOnPage.read(AnyView(page), model: model)
        let expected = groups.flatMap { $0.preferences.map(\.key) + ["end of \($0.title)"] }
        #expect(rows.preferences == top + expected + ["custom"])
        #expect(rows.disabled == first.preferences.map(\.key), "only the unavailable group's preferences")
    }

    @Test(
        "Screengrabs' page shows Screen Recording once, as the template's required row, missing or granted, and Accessibility, the Microphone, and Input Monitoring as optional (#490)",
        arguments: [MacPermission.screenRecording, nil]
    )
    func screengrabsPermissions(missing: MacPermission?) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsScreengrabsPermissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: Set(Capability.allCases), missing: missing, root: root)
        harness.model.start()
        #expect(harness.model.permissions.screenRecordingGranted == (missing == nil))
        let page = try #require(CapabilityDescriptor.screenshotTools.settingsPage)
        let rows = RowsOnPage.read(page.content(), model: harness.model)
        #expect(rows.permissions == [
            PermissionRow.Shown(permission: .screenRecording, isOptional: false),
            PermissionRow.Shown(permission: .accessibility, isOptional: true),
            PermissionRow.Shown(permission: .microphone, isOptional: true),
            PermissionRow.Shown(permission: .inputMonitoring, isOptional: true),
        ])
    }

    @Test("The pages on the template show the permissions they need, such as Keystrokes' Input Monitoring and Screengrabs' Screen Recording (#490)")
    func templatePagesShowRequiredPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsTemplateRequiredPermissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root).model
        func required(_ descriptor: CapabilityDescriptor) throws -> [PermissionRow.Shown] {
            let page = try #require(descriptor.settingsPage, "\(descriptor.title) has a Settings page")
            return RowsOnPage.read(page.content(), model: model).permissions.filter { !$0.isOptional }
        }
        #expect(try required(.keystrokes) == [PermissionRow.Shown(permission: .inputMonitoring, isOptional: false)])
        #expect(try required(.screenshotTools) == [PermissionRow.Shown(permission: .screenRecording, isOptional: false)])
        for descriptor in [CapabilityDescriptor.timer, .emojiPicker, .translation, .keystrokes, .screenshotTools] {
            let declared = MacPermission.allCases.filter(descriptor.requiredPermissions.contains)
            #expect(try required(descriptor).map(\.permission) == declared, "\(descriptor.title) shows each permission it needs")
        }
    }

    @Test("Screengrabs' page shows the watcher's status and what fixes it, in each of its states, then Copy new screenshots, then the recordings folder at the end of Recordings (#490)")
    func screenshotToolsRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsScreenshotToolsRows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let everything = Set(Capability.allCases)
        let copy: [ScreenshotsSettings.Row] = [.copiesScreenshotsToClipboard, .about, .recordingsFolder]
        let readable = FakeScreenshotDirectoryReader(granted: true)
        let states: [(status: String, enabled: Set<Capability>, missing: MacPermission?, reader: any ScreenshotDirectoryReading, rows: [ScreenshotsSettings.Row])] = [
            ("watching", everything, nil, readable, [.watching] + copy),
            ("watching", everything, .screenRecording, readable, [.watching] + copy),
            ("off", everything.subtracting([.screenshotTools]), nil, readable, [.off] + copy),
            ("requiresClipboardHistory", everything.subtracting([.clipboardHistory]), nil, readable, [.requiresClipboardHistory, .enableClipboardHistory] + copy),
            (
                "folderAccessDenied", everything, nil, FakeScreenshotDirectoryReader(granted: false),
                [.folderAccessDenied, .folderAccessHelp, .openPrivacyAndSecurity] + copy
            ),
            ("folderUnavailable", everything, nil, UnavailableScreenshotFolder(), [.folderUnavailable, .folderUnavailableHelp] + copy),
        ]
        let page = try #require(CapabilityDescriptor.screenshotTools.settingsPage)
        for state in states {
            let harness = WiringHarness(enabled: state.enabled, missing: state.missing, root: root, screenshotReader: state.reader)
            harness.model.start()
            let label = "\(state.status), \(state.missing?.rawValue ?? "nothing") missing"
            #expect(Self.describe(harness.model.screenshotTools.status) == state.status, "\(label)")
            #expect(RowsOnPage.read(page.content(), model: harness.model).screenshots == state.rows, "\(label)")
        }
    }

    @Test("On macOS 14, Screengrabs' Recordings group says recording needs macOS 15, in place of the folder, and its preferences can't change; screenshots are as on macOS 15 (#490)")
    func recordingsOnMacOS14() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsScreengrabs14-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(CapabilityDescriptor.screenshotTools.settingsPage)
        let recording = CapabilityDescriptor.screenshotTools.preferences.map(\.key)

        let old = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root, compatibility: PluginCompatibility(macOSMajorVersion: 14))
        old.model.start()
        let oldRows = RowsOnPage.read(page.content(), model: old.model)
        #expect(oldRows.screenshots == [.watching, .copiesScreenshotsToClipboard, .about, .recordingRequirement])
        #expect(oldRows.preferences == recording)
        #expect(oldRows.disabled == recording)

        let current = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root, compatibility: PluginCompatibility(macOSMajorVersion: 15))
        current.model.start()
        let currentRows = RowsOnPage.read(page.content(), model: current.model)
        #expect(currentRows.screenshots == [.watching, .copiesScreenshotsToClipboard, .about, .recordingsFolder])
        #expect(currentRows.disabled.isEmpty)
    }

    @Test("On macOS 14, Screengrabs' note and its switch's tooltip don't say Keybumps takes ⇧⌘5 or runs Record Screen, as it does neither there (#490)")
    func macOS14KeepsItsShiftCommand5InWords() throws {
        let page = try #require(CapabilityDescriptor.screenshotTools.settingsPage)
        let old = PluginCompatibility(macOSMajorVersion: 14)
        let current = PluginCompatibility(macOSMajorVersion: 15)

        let oldNote: String = ScreenshotsSettings.about(on: old)
        let oldTooltip: String = try #require(page.disableExplanation(on: old))
        #expect(!oldNote.contains("⇧⌘5"))
        #expect(oldNote.contains("⇧⌘3 and ⇧⌘4"))
        #expect(!oldTooltip.contains("⇧⌘5"))
        #expect(!oldTooltip.contains("Record Screen"))
        #expect(oldTooltip.contains("⇧⌘3 and ⇧⌘4"))

        let currentNote: String = ScreenshotsSettings.about(on: current)
        let currentTooltip: String = try #require(page.disableExplanation(on: current))
        #expect(currentNote.contains("⇧⌘3, ⇧⌘4, and ⇧⌘5"))
        #expect(currentTooltip.contains("⇧⌘3, ⇧⌘4, and ⇧⌘5"))
        #expect(currentTooltip.contains("Record Screen"))
    }

    @Test("On macOS 14, Record Screen's row can't change, neither its field nor Restore default, while the screenshot hotkeys' can; on macOS 15 it can (#490)")
    func recordScreenRowOnMacOS14() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsRecordScreenRow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try #require(CapabilityDescriptor.screenshotTools.settingsPage)
        for version in [14, 15] {
            let runs = version >= 15
            let compatibility = PluginCompatibility(macOSMajorVersion: version)
            let harness = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root, compatibility: compatibility)
            // Without ⇧⌘5, the row shows Restore default.
            harness.model.preferences.setCapabilityShortcut(nil, for: .screencast)
            let controls: [ShortcutRowControl] = RowsOnPage.read(page.content(), model: harness.model).controls
            let recordScreen = controls.filter { $0.shortcut == .screencast }
            let expected: [ShortcutRowControl] = [
                ShortcutRowControl(shortcut: .screencast, control: .field, isEnabled: runs),
                ShortcutRowControl(shortcut: .screencast, control: .restoreDefault, isEnabled: runs),
            ]
            #expect(recordScreen == expected, "macOS \(version)")
            let area = controls.filter { $0.shortcut == .screenshotArea && $0.control == .field }
            #expect(area.map(\.isEnabled) == [true], "macOS \(version): a screenshot hotkey's field")
        }
    }

    @Test("A page that names no recording has one switch tooltip on every Mac")
    func tooltipWithoutRecordingVariant() throws {
        let page = try #require(CapabilityDescriptor.timer.settingsPage)
        let old: String? = page.disableExplanation(on: PluginCompatibility(macOSMajorVersion: 14))
        #expect(old == page.disableExplanation)
    }

    @Test("Copy new screenshots to the clipboard keeps its own key, not a declared preference's (#490)")
    func copyKeepsItsKey() {
        #expect(!CapabilityDescriptor.screenshotTools.preferences.map(\.key).contains("copiesScreenshotsToClipboard"))
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.copiesScreenshotsToClipboard = false
        #expect(defaults.object(forKey: "copiesScreenshotsToClipboard") as? Bool == false)
    }

    private static func describe(_ status: ScreenshotToolsStatus) -> String {
        switch status {
        case .stopped: "off"
        case .requiresClipboardHistory: "requiresClipboardHistory"
        case .watching: "watching"
        case .folderAccessDenied: "folderAccessDenied"
        case .folderUnavailable: "folderUnavailable"
        }
    }

    /// Stands in for a row in a page's slot, in the order the declared preferences report theirs.
    private struct Marker: View {
        let name: String
        var body: some View {
            Text(name).preference(key: PluginPreferenceRow.Shown.self, value: [name])
        }
    }

    /// A screenshot folder that can't be read for a reason other than access, such as a disk
    /// that isn't connected.
    private struct UnavailableScreenshotFolder: ScreenshotDirectoryReading {
        func entries(in folder: URL) throws -> [ScreenshotDirectoryEntry] {
            throw ScreenshotFolderReadError.unavailable
        }
    }
}

/// Lays out a Settings page in a window that's never shown, as `ShortcutConflictTests` does, and
/// returns the permission rows and the preference rows it draws, those it draws disabled, the
/// rows of Screengrabs' own (its Screenshots group, and the end of its Recordings group), and its
/// shortcut rows' controls, in order.
@MainActor
private enum RowsOnPage {
    private final class Rows: @unchecked Sendable {
        var permissions: [PermissionRow.Shown] = []
        var preferences: [String] = []
        var disabled: [String] = []
        var screenshots: [ScreenshotsSettings.Row] = []
        var controls: [ShortcutRowControl] = []
    }

    static func read(_ page: AnyView, model: AppModel) -> (
        permissions: [PermissionRow.Shown], preferences: [String], disabled: [String], screenshots: [ScreenshotsSettings.Row],
        controls: [ShortcutRowControl]
    ) {
        let rows = Rows()
        let size = CGSize(width: 720, height: 4000)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: page
            .environment(model)
            .onPreferenceChange(PermissionRow.Shown.Key.self) { rows.permissions = $0 }
            .onPreferenceChange(PluginPreferenceRow.Shown.self) { rows.preferences = $0 }
            .onPreferenceChange(PluginPreferenceRow.Disabled.self) { rows.disabled = $0 }
            .onPreferenceChange(ScreenshotsSettings.Shown.self) { rows.screenshots = $0 }
            .onPreferenceChange(ShortcutRowControl.Shown.self) { rows.controls = $0 })
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        return (rows.permissions, rows.preferences, rows.disabled, rows.screenshots, rows.controls)
    }
}
