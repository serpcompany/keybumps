import Foundation
import Testing

struct EntitlementsSourceTests {
    @Test func declaresMicrophoneCaptureEntitlement() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Keybumps/Resources/Keybumps.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let entitlements = try #require(plist as? [String: Any])
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
    }
}
