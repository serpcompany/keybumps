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
}
