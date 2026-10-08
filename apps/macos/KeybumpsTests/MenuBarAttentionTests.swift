import Testing
@testable import Keybumps

@MainActor
@Suite("The menu bar dot")
struct MenuBarAttentionTests {
    @Test("One dot shows while any reason is active, and each change redraws once")
    func dotFollowsReasons() {
        let attention = MenuBarAttention()
        var redraws = 0
        attention.onChange = { redraws += 1 }
        #expect(!attention.showsDot)

        attention.show(.update, saying: "update ready")
        attention.show(.update, saying: "update ready")
        #expect(attention.showsDot)
        #expect(redraws == 1, "Showing the same reason again changes nothing")

        let snippets = CapabilityMenuBarAttention(attention: attention, capability: .snippets)
        snippets.show(saying: "snippets need you")
        attention.clear(.update)
        #expect(attention.showsDot, "The capability's reason keeps the dot")

        snippets.clear()
        snippets.clear()
        #expect(!attention.showsDot)
        #expect(redraws == 4)
    }

    @Test("VoiceOver names every reason: updates first, then capabilities in registry order")
    func accessibilityLabel() {
        let attention = MenuBarAttention()
        #expect(attention.accessibilityLabel(productName: "Keybumps") == "Keybumps")

        CapabilityMenuBarAttention(attention: attention, capability: .snippets).show(saying: "snippets need you")
        CapabilityMenuBarAttention(attention: attention, capability: .clipboardHistory).show(saying: "clipboard needs you")
        attention.show(.update, saying: "update ready")
        #expect(
            attention.accessibilityLabel(productName: "Keybumps")
                == "Keybumps, update ready, clipboard needs you, snippets need you"
        )
    }
}
