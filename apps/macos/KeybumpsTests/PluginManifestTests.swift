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
        #expect(PluginSettingsPage<EmptyView>.byline(.timer) == "Official plugin by Keybumps · Productivity")
    }

    @Test("A plugin's shortcuts and preference groups come from its manifest, in order")
    func derived() {
        #expect(CapabilityDescriptor.timer.shortcuts == [.timer])
        #expect(CapabilityDescriptor.screenshotTools.shortcuts == [.screenshotScreen, .screenshotScreenAndEdit, .screenshotArea])
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

    @Test("Every plugin ships on except the Emoji Picker, the first that ships off (#243)")
    func onlyTheEmojiPickerShipsOff() {
        #expect(CapabilityCatalog.descriptors.filter { !$0.isOnByDefault }.map(\.capability) == [.emojiPicker])
        #expect(CapabilityDescriptor.emojiPicker.optionalPermissions.map(\.permission) == [.accessibility])
    }
}
